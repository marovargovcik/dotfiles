#!/usr/bin/env bats
# tt proj: the repo's session, with a window for every worktree that has none.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
}

teardown() {
    teardown_tt
}

@test "the session comes with a window per worktree, each resuming its newest conversation" {
    git worktree add -q -b one "$tmp/wt/one"
    git worktree add -q -b two "$tmp/wt/two"
    conversation "$tmp/wt/one" 1111
    run "$tt" proj </dev/null
    # Outside tmux it attaches, which fails without a terminal.
    assert_equal "$(tmux list-windows -t app -F '#{window_name}:#{@task_path}')" "orch:
one:$tmp/wt/one
two:$tmp/wt/two"
    eventually claude_ran "$tmp/wt/one" '--resume 1111'
    eventually claude_ran "$tmp/wt/two" ''
}

@test "a worktree with a window already gets no second one" {
    git worktree add -q -b one "$tmp/wt/one"
    "$tt" proj </dev/null || true
    "$tt" proj </dev/null || true
    assert_equal "$(tmux list-windows -t app | wc -l)" 2
}

@test "a worktree that was deleted gets no window" {
    git worktree add -q -b one "$tmp/wt/one"
    rm -rf "$tmp/wt/one"
    "$tt" proj </dev/null || true
    assert_equal "$(tmux list-windows -t app | wc -l)" 1
}

@test "a directory outside git is refused" {
    run "$tt" proj "$tmp" </dev/null
    assert_failure
    assert_output "tt: $tmp is not in a git repo"
}
