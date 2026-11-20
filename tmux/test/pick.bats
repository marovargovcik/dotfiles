#!/usr/bin/env bats
# tt pick's rows, a tree of sessions, windows and panes with the agents' states, and its preview of a row's pane.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    "$tt" new task </dev/null
    task=$(pane_of "$TT_WORKTREES/app/task")
    orch=$(tmux display -p -t app:0 '#{pane_id}')
}

teardown() {
    teardown_tt
}

# plain: stdin without its colours.
plain() { sed $'s/\033\\[[0-9;]*m//g'; }

# rule <width>: a session row's rule.
rule() { printf '─%.0s' $(seq "$1"); }

@test "a session, its windows and the panes of a split one, as a tree, each with its most urgent state" {
    agent_in "$orch" "done"
    agent_in "$task" blocked
    tmux select-pane -t "$task" -T '✳ Fix the login'
    shell=$(tmux split-window -d -P -F '#{pane_id}' -t "$task" -c "$tmp/app")
    run "$tt" _pick-rows
    assert_success
    assert_equal "$(plain <<<"$output" | tr '\t' '|')" "$(tag app session_id)|⚠ app $(rule 37) 2 windows
$(tag app:0 window_id)|✓ ├─ 0 orch ◆     done     app  app:0
$(tag app:1 window_id)|⚠ └─ 1 task task  blocked  Fix the login  app:1
$task|⚠    ├─ .0        blocked  Fix the login  app:1.0
$shell|     └─ .1        bash     app  app:1.1
$(tag keep session_id)|  keep $(rule 36) 1 window
$(tag keep:0 window_id)|  └─ 0 bash       bash     home  keep:0"
}

@test "the icons: red blocked, green done and not looked at, yellow working, dim done and seen" {
    agent_in "$task" working
    run "$tt" _pick-rows
    assert_line --index 2 --partial $'\033[33m…\033[0m └─ 1'
    TMUX_PANE=$task "$tt" state "done" <<<"{\"session_id\": \"session-${task#%}\"}"
    run "$tt" _pick-rows
    assert_line --index 2 --partial $'\033[32m✓\033[0m └─ 1'
    tmux set -p -t "$task" @agent_seen 1
    run "$tt" _pick-rows
    assert_line --index 2 --partial $'\033[2m✓\033[0m └─ 1'
}

@test "the preview of a pane is what it shows, without the blank lines below" {
    shell=$(tmux new-window -d -P -F '#{pane_id}' -t keep:)
    tmux send-keys -t "$shell" 'echo previewed' Enter
    eventually shows "$shell" previewed
    run --keep-empty-lines "$tt" _preview "$shell"
    assert_equal "${lines[-2]}" previewed
}

@test "the preview of a split window stacks its panes, each under a tag" {
    shell=$(tmux split-window -d -P -F '#{pane_id}' -t "$task" -c "$tmp/app")
    FZF_PREVIEW_LINES=10 FZF_PREVIEW_COLUMNS=30 run --keep-empty-lines "$tt" _preview "$(tag "$task" window_id)"
    assert_equal "$(plain <<<"$output" | grep -c 'app:1')" 2
    assert_line --index 0 --partial ' app:1.0  claude  task  ◀ ac'
    assert_line --index 5 --partial ' app:1.1  bash  app '
}
