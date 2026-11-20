#!/usr/bin/env bats
# tt new: a worktree and a task window for the repo in $PWD, with claude started on the prompt.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
}

teardown() {
    teardown_tt
}

@test "a new branch gets a worktree, a task window in the repo's session and claude on the prompt" {
    run "$tt" new -p 'fix the login' feat/login </dev/null
    assert_success
    path=$TT_WORKTREES/app/feat-login
    assert_output "$(tmux display -p -t "$(window_of "$path")" '#{pane_id}')"
    assert_equal "$(git -C "$path" branch --show-current)" feat/login
    assert_equal "$(tag "$(window_of "$path")" @task)" feat/login
    assert_equal "$(tag "$(window_of "$path")" window_name)" feat/login
    eventually claude_ran "$path" 'fix the login'
}

@test "the repo's session comes first, tagged, with claude resuming in orch" {
    conversation "$tmp/app" 1111
    run "$tt" new feat/login </dev/null
    assert_success
    session=$(tmux list-sessions -F '#{session_name} #{@kind} #{@repo}' | grep -v '^keep')
    assert_equal "$session" "app agent $tmp/app"
    assert_equal "$(tmux list-windows -t app -F '#{window_name} #{@role}' | head -1)" "orch orchestrator"
    eventually claude_ran "$tmp/app" '--resume 1111'
    eventually claude_ran "$TT_WORKTREES/app/feat-login" ''
}

@test "a new branch starts from the given base, without tracking it" {
    git commit -q --allow-empty -m second
    git branch base HEAD~1
    run "$tt" new feat/x base </dev/null
    assert_success
    path=$TT_WORKTREES/app/feat-x
    assert_equal "$(git -C "$path" rev-parse HEAD)" "$(git rev-parse base)"
    run git -C "$path" rev-parse --abbrev-ref '@{upstream}'
    assert_failure
}

@test "an existing branch is checked out in the worktree" {
    git branch old
    run "$tt" new old </dev/null
    assert_success
    assert_equal "$(git -C "$TT_WORKTREES/app/old" branch --show-current)" old
}

@test "a worktree that exists already is refused" {
    mkdir -p "$TT_WORKTREES/app/feat-x"
    run "$tt" new feat/x </dev/null
    assert_failure
    assert_output "tt: $TT_WORKTREES/app/feat-x already exists"
}

@test "outside a repo it refuses" {
    cd "$tmp"
    run "$tt" new feat/x </dev/null
    assert_failure
    assert_output "tt: not in a git repo"
}

@test "with no branch given or typed, nothing happens" {
    run "$tt" new <<<''
    assert_success
    assert_equal "$(tmux list-sessions -F '#{session_name}')" keep
}
