#!/usr/bin/env bats
# tt archive and tt archived: a task's worktree goes, its branch stays, and the log remembers it for restore.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    "$tt" new nux-12-login </dev/null
    path=$TT_WORKTREES/app/nux-12-login
    window=$(window_of "$path")
}

teardown() {
    teardown_tt
}

@test "the worktree and window go, the branch stays, and the log gets a line" {
    conversation "$path" 2222
    tmux select-pane -t "$window" -T '✳ Fix the login'
    run "$tt" archive "$window"
    assert_success
    assert_output --regexp '^\[1/1\] Fix the login \(nux-12-login\): archived in [0-9]+s$'
    assert [ ! -e "$path" ]
    assert_equal "$(window_of "$path")" ""
    git show-ref -q --verify refs/heads/nux-12-login
    assert_equal "$(cat "$XDG_STATE_HOME/tt/archive.tsv")" \
        "$(printf '%s\t' "$(date +%F)" "$tmp/app" nux-12-login "$path" 2222)Fix the login"
}

@test "a worktree with uncommitted changes is kept" {
    touch "$path/new-file"
    run "$tt" archive "$window"
    assert_failure
    assert_output "tt: nux-12-login has uncommitted changes; kept"
    assert [ -e "$path" ]
    assert_equal "$(window_of "$path")" "$window"
}

@test "a window that isn't a task is refused" {
    run "$tt" archive "$(tag keep window_id)"
    assert_failure
    assert_output --partial "is not a task window"
}

@test "node_modules goes aside before the worktree, and is deleted after it" {
    mkdir "$path/node_modules"
    echo node_modules >"$path/.gitignore"
    git -C "$path" add .gitignore && git -C "$path" commit -qm ignore
    run "$tt" archive "$window"
    assert_success
    assert [ ! -e "$path" ]
    assert [ -d "$XDG_CACHE_HOME/tt/trash" ]
    eventually empty "$XDG_CACHE_HOME/tt/trash"
}

@test "a worktree git won't remove comes back in a window, and leaves the log as it was" {
    git -C "$tmp/app" worktree lock "$path"
    run "$tt" archive "$window"
    assert_failure
    assert_line --index 0 "[1/1]  (nux-12-login): not archived"
    assert [ -e "$path" ]
    assert [ -n "$(window_of "$path")" ]
    assert [ ! -s "$XDG_STATE_HOME/tt/archive.tsv" ]
}

@test "with no window given, the tasks picked with fzf go" {
    "$tt" new other </dev/null
    FZF_PICK=nux-12 run "$tt" archive
    assert_success
    assert [ ! -e "$path" ]
    assert [ -e "$TT_WORKTREES/app/other" ]
    assert_equal "$(cut -f1 "$tmp/fzf.in")" "$window
$(window_of "$TT_WORKTREES/app/other")"
}

@test "picking nothing archives nothing" {
    run "$tt" archive
    assert_success
    assert [ -e "$path" ]
}

@test "the picker's rows: repo, title and branch, then what archiving would set aside" {
    tmux select-pane -t "$window" -T '✳ Fix the login'
    git -C "$path" commit -q --allow-empty -m work
    run "$tt" _archive-rows --status
    assert_success
    assert_output "$window$(printf '\t')app          Fix the login                      nux-12-login                 1 ahead · not pushed"
}

@test "a task's statuses: uncommitted files, a PR, nothing done" {
    touch "$path/a" "$path/b"
    stub gh 'echo MERGED'
    run "$tt" _archive-rows --status
    assert_output --partial "nux-12-login                 2 uncommitted · pr merged"
    rm "$path/a" "$path/b"
    stub gh 'exit 1'
    run "$tt" _archive-rows --status
    assert_output --partial "nux-12-login                 untouched"
}

@test "with no tasks, archive says so" {
    "$tt" archive "$window"
    run "$tt" archive
    assert_failure
    assert_output "tt: no tasks"
}

@test "archived lists the log: date, repo, branch, title" {
    tmux select-pane -t "$window" -T '✳ Fix the login'
    "$tt" archive "$window" 2>/dev/null
    run "$tt" archived
    assert_output "$(date +%F)  app            nux-12-login                 Fix the login"
}

@test "archived with nothing archived" {
    run "$tt" archived
    assert_output "nothing archived"
}
