#!/usr/bin/env bats
# tt send and tt read: handing work to another pane, and seeing what it shows.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    "$tt" new task </dev/null
    pane=$(pane_of "$TT_WORKTREES/app/task")
}

teardown() {
    teardown_tt
}

@test "an idle agent gets the hand-off pasted and submitted" {
    agent_in "$pane"
    run "$tt" send "$pane" 'look at this'
    assert_success
    assert_output "$pane: sent"
    eventually shows "$pane" 'look at this'
}

@test "a working agent gets it queued" {
    agent_in "$pane" working
    run "$tt" send "$pane" 'and this'
    assert_output "$pane: queued (it's working)"
    eventually shows "$pane" 'and this'
}

@test "a blocked agent gets nothing" {
    agent_in "$pane" blocked
    run "$tt" send "$pane" 'and this'
    assert_failure
    assert_output "tt: $pane is waiting on you; nothing sent"
}

@test "a shell starts claude on the hand-off, in its directory" {
    shell=$(tmux new-window -d -P -F '#{pane_id}' -t keep: -c "$tmp/app")
    eventually runs "$shell" bash
    run "$tt" send "$shell" 'a long hand-off'
    assert_output "$shell: started claude"
    eventually claude_ran "$tmp/app" 'a long hand-off'
}

@test "a pane running anything else gets nothing" {
    other=$(tmux new-window -d -P -F '#{pane_id}' -t keep: 'sleep 30')
    eventually runs "$other" sleep
    run "$tt" send "$other" 'hello'
    assert_failure
    assert_output "tt: $other is running sleep, not a shell; nothing sent"
}

@test "an agent that was killed leaves a shell, which starts claude" {
    agent_in "$pane" working
    tmux send-keys -t "$pane" C-d
    eventually runs "$pane" bash
    run "$tt" send "$pane" 'start over'
    assert_output "$pane: started claude"
}

@test "send refuses a missing pane or hand-off" {
    run "$tt" send %999 hello
    assert_failure
    run "$tt" send "$pane"
    assert_failure
    assert_output "tt: send needs a pane and a hand-off"
}

@test "read shows the pane without the blank lines after its output" {
    shell=$(tmux new-window -d -P -F '#{pane_id}' -t keep:)
    tmux send-keys -t "$shell" 'echo some output' Enter
    eventually shows "$shell" 'some output'
    run --keep-empty-lines "$tt" read "$shell"
    assert_success
    assert_equal "${lines[-2]}" 'some output'
    assert_regex "${lines[-1]}" '\$ $'
}
