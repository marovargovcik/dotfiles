#!/usr/bin/env bats
# tt state, run by the agent's hooks, and tt count, the status line's sum of what needs looking at.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_tt
    git_repo app
    "$tt" new task </dev/null
    pane=$(pane_of "$TT_WORKTREES/app/task")
    eventually runs "$pane" claude
}

teardown() {
    teardown_tt
}

# hook <state> <json> [agent]: tt state as the agent's hook in the task's pane runs it.
hook() { TMUX_PANE=$pane "$tt" state "$1" ${3:+"$3"} <<<"$2"; }

@test "start tags the pane with the agent and its session, and records it for tt up" {
    hook start '{"session_id": "s1", "source": "startup"}'
    assert_equal "$(tag "$pane" @agent) $(tag "$pane" @agent_session)" "claude s1"
    run cut -f5,8 "$XDG_STATE_HOME/tt/open.tsv"
    assert_output "task$(printf "\t")s1"
}

@test "a state change tags the pane, not seen while nobody looks at it" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook working '{"session_id": "s1"}'
    assert_equal "$(tag "$pane" @agent_state)" working
    tmux set -p -t "$pane" @agent_seen 1
    hook "done" '{"session_id": "s1"}'
    assert_equal "$(tag "$pane" @agent_state)" "done"
    assert_equal "$(tag "$pane" @agent_seen)" ""
}

@test "the same state again changes nothing" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook "done" '{"session_id": "s1"}'
    tmux set -p -t "$pane" @agent_seen 1
    hook "done" '{"session_id": "s1"}'
    assert_equal "$(tag "$pane" @agent_seen)" 1
}

@test "events from another session in the pane are ignored" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook working '{"session_id": "s2"}'
    assert_equal "$(tag "$pane" @agent_state)" ""
}

@test "a start from a claude -p inside the agent leaves the pane to the agent" {
    # An agent no process above the hook is named after, as for a claude -p off the terminal: the tests may run
    # inside a real claude.
    hook start '{"session_id": "s1", "source": "startup"}' codex
    hook start '{"session_id": "s2", "source": "startup"}' codex
    assert_equal "$(tag "$pane" @agent_session)" s1
}

@test "/clear and /resume switch the pane to the new session" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook start '{"session_id": "s2", "source": "clear"}'
    assert_equal "$(tag "$pane" @agent_session)" s2
}

@test "clear removes the tags" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook working '{"session_id": "s1"}'
    hook clear '{"session_id": "s1"}'
    assert_equal "$(tag "$pane" @agent)$(tag "$pane" @agent_session)$(tag "$pane" @agent_state)" ""
}

@test "another agent's hooks name it" {
    hook start '{"session_id": "s1", "source": "startup"}' codex
    assert_equal "$(tag "$pane" @agent)" codex
}

@test "an unknown state is refused" {
    run hook sleeping '{"session_id": ""}'
    assert_failure
    assert_output "tt: state is start, working, done, blocked or clear"
}

@test "outside tmux nothing is tagged" {
    run env -u TMUX_PANE "$tt" state working <<<'{"session_id": "s1"}'
    assert_success
    assert_equal "$(tag "$pane" @agent_state)" ""
}

@test "the agent's state goes to a file named after its pid, in tmux or not" {
    mkdir "$tmp/agent"
    ln -s "$(command -v bash)" "$tmp/agent/claude"
    # shellcheck disable=SC2016 # expanded by the agent's shell
    "$tmp/agent/claude" -c 'echo $$ >"$1/pid"; "$2" state working <<<"{\"session_id\": \"s1\"}"; true' _ "$tmp" "$tt"
    assert_equal "$(cat "$XDG_RUNTIME_DIR/agents/$(cat "$tmp/pid")")" "working$(printf "\t")s1"
    # shellcheck disable=SC2016 # expanded by the agent's shell
    "$tmp/agent/claude" -c 'echo $$ >"$1/pid"; "$2" state clear <<<"{}"; true' _ "$tmp" "$tt"
    assert [ ! -e "$XDG_RUNTIME_DIR/agents/$(cat "$tmp/pid")" ]
}

@test "count: blocked agents, and finished ones nobody looked at" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook blocked '{"session_id": "s1"}'
    second=$(tmux split-window -d -P -F '#{pane_id}' -t "$pane" claude)
    agent_in "$second" "done"
    run "$tt" count
    assert_output "⚠1 ✓1 "
    tmux set -p -t "$second" @agent_seen 1
    run "$tt" count
    assert_output "⚠1 "
}

@test "count ignores the tags of an agent that's gone" {
    hook start '{"session_id": "s1", "source": "startup"}'
    hook blocked '{"session_id": "s1"}'
    tmux send-keys -t "$pane" C-d
    eventually runs "$pane" bash
    run "$tt" count
    assert_output ""
}
