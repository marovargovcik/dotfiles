#!/usr/bin/env bats
# tt places: where a request about a ticket, path or repo belongs, most specific first.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    "$tt" new nux-12-login </dev/null
    login=$TT_WORKTREES/app/nux-12-login
    orch=$(tmux display -p -t app:0 '#{pane_id}')
}

teardown() {
    teardown_tt
}

@test "a ticket key: the task working on it, and a shell in its worktree" {
    agent_in "$(pane_of "$login")" working
    shell=$(tmux split-window -d -P -F '#{pane_id}' -t "$(window_of "$login")" -c "$login")
    run "$tt" places NUX-12
    assert_success
    assert_output "task   $(pane_of "$login")  working  $login
shell  $shell  -        $login"
}

@test "the pane asking is this" {
    pane=$(pane_of "$login")
    agent_in "$pane"
    TMUX_PANE=$pane run "$tt" places nux-12
    assert_output "this  $pane  idle  $login"
}

@test "an archived task, and a worktree whose window was closed" {
    "$tt" new nux-12-signup </dev/null
    "$tt" archive "$(window_of "$login")" 2>/dev/null
    tmux kill-window -t "$(window_of "$TT_WORKTREES/app/nux-12-signup")"
    run "$tt" places NUX-12
    assert_output "archived  nux-12-login   -  $login
closed    nux-12-signup  -  $TT_WORKTREES/app/nux-12-signup"
}

@test "a path: the agents and shells in the checkout" {
    agent_in "$orch"
    run "$tt" places "$tmp/app"
    assert_output "session  $orch  idle  $tmp/app"
}

@test "a repo's name: its main checkout" {
    agent_in "$orch" blocked
    run "$tt" places app
    assert_output "session  $orch  blocked  $tmp/app"
}

@test "nothing for an unknown repo, or a key no task has" {
    run "$tt" places nope
    assert_failure
    assert_output "tt: no place for nope"
    run "$tt" places NUX-99
    assert_failure
    assert_output "tt: no place for NUX-99"
}

@test "places needs something to look for" {
    run "$tt" places
    assert_failure
    assert_output "tt: places needs a ticket key, path or repo name"
}
