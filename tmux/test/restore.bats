#!/usr/bin/env bats
# tt restore: an archived task's worktree back at the same path, claude resuming its conversation.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    for branch in nux-12-login nux-34-signup; do
        "$tt" new "$branch" </dev/null
        conversation "$TT_WORKTREES/app/$branch" "id-$branch"
        "$tt" archive "$(window_of "$TT_WORKTREES/app/$branch")" 2>/dev/null
    done
}

teardown() {
    teardown_tt
}

@test "the task whose branch has the key comes back, resuming its conversation on the prompt" {
    run "$tt" restore -p 'carry on' NUX-12 </dev/null
    assert_success
    path=$TT_WORKTREES/app/nux-12-login
    assert_output "$(tmux display -p -t "$(window_of "$path")" '#{pane_id}')"
    assert_equal "$(git -C "$path" branch --show-current)" nux-12-login
    eventually claude_ran "$path" '--resume id-nux-12-login carry on'
    run cut -f3 "$XDG_STATE_HOME/tt/archive.tsv"
    assert_output nux-34-signup
}

@test "a key matches a whole segment of the branch only" {
    run "$tt" restore NUX-1 </dev/null
    assert_failure
    assert_output "tt: nothing archived matches NUX-1"
}

@test "with no key, the task picked with fzf, newest last and the repo of \$PWD as the query" {
    FZF_PICK=signup run "$tt" restore </dev/null
    assert_success
    assert [ -d "$TT_WORKTREES/app/nux-34-signup" ]
    assert_equal "$(cut -f1 "$tmp/fzf.in")" "1
2"
    assert_equal "$(sed -n 1p "$tmp/fzf.in" | cut -f2 | tr -s ' ')" "$(date +%F) app nux-12-login "
    grep -qxF -- "--query='app " "$tmp/fzf.args"
}

@test "picking nothing restores nothing" {
    run "$tt" restore </dev/null
    assert_success
    assert_equal "$(wc -l <"$XDG_STATE_HOME/tt/archive.tsv")" 2
}

@test "with nothing archived it refuses" {
    rm "$XDG_STATE_HOME/tt/archive.tsv"
    run "$tt" restore NUX-12 </dev/null
    assert_failure
    assert_output "tt: nothing archived"
}
