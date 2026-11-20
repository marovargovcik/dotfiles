#!/usr/bin/env bats
# caffeine-agents' rule for whether a terminal is working, against a made-up
# process table: the lib is sourced, with procs reading the table from a file.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

pts=$((136 << 8)) # a pseudo-terminal's device number, as /proc/<pid>/stat has it
tty1=$((4 << 8 | 1))

setup() {
    isolate find getconf
    # shellcheck source=../.local/lib/caffeine/agents.sh
    source "$bin/../lib/caffeine/agents.sh"
    # shellcheck disable=SC2329 # working calls it
    procs() { cat "$tmp/procs"; }
    hz=100
    mkdir -p "$agents"
}

teardown() {
    [ -z "${tool:-}" ] || kill "$tool" 2>/dev/null || true
}

# processes <pid parent group session tty foreground ticks>...: the table.
processes() { printf '%s\n' "$@" >"$tmp/procs"; }

# agent <state> [session]: the hooks' file for the agent with pid 200.
agent() { printf '%s\t%s\n' "$1" "${2:-}" >"$agents/200"; }

# in_front <ticks> [extra row...]: a shell (100) on a terminal with process 200
# in front of it, which has used that much CPU.
in_front() {
    processes "100 1 100 100 $pts 200 5" "200 100 200 100 $pts 200 $1" "${@:2}"
}

@test "a shell at its prompt is idle" {
    processes "100 1 100 100 $pts 100 5"
    run working
    assert_failure
}

@test "a program in front that used 5% of a CPU since the last check is working" {
    in_front 1000
    working || true
    in_front $((1000 + 3 * hz))
    run working
    assert_success
}

@test "a program in front that used less, or wasn't there at the last check, is idle" {
    in_front 1000
    run working
    assert_failure
    working || true
    in_front $((1000 + 3 * hz - 1))
    run working
    assert_failure
}

@test "a program's children it waited for count towards it" {
    in_front 1000 "300 200 200 100 $pts 200 0"
    working || true
    in_front 1000 "300 200 200 100 $pts 200 $((3 * hz))"
    run working
    assert_success
}

@test "the console sway runs on is not a terminal" {
    processes "100 1 100 100 $tty1 200 5" "200 100 200 100 $tty1 200 1000"
    working || true
    processes "100 1 100 100 $tty1 200 5" "200 100 200 100 $tty1 200 $((1000 + 10 * hz))"
    run working
    assert_failure
}

@test "an agent its hooks recorded as working is working" {
    in_front 0
    agent working s1
    run working
    assert_success
}

@test "an agent past its turn is idle" {
    in_front 0
    agent "done" s1
    run working
    assert_failure
}

@test "an agent past its turn with a Bash tool command running is working" {
    # A shell like the one the Bash tool runs, sourcing its snapshot.
    bash -c 'sleep 30; true' _ "$HOME/.claude/shell-snapshots/snapshot-bash.sh" >/dev/null 2>&1 3>&- &
    tool=$!
    in_front 0 "$tool 200 200 100 $pts 200 0"
    agent "done" s1
    run working
    assert_success
}

@test "an agent past its turn with a subagent whose transcript changed in the last two minutes is working" {
    in_front 0
    agent blocked s1
    mkdir -p "$HOME/.claude/projects/-repo/s1/subagents"
    touch -d '3 minutes ago' "$HOME/.claude/projects/-repo/s1/subagents/agent-a.jsonl"
    run working
    assert_failure
    touch "$HOME/.claude/projects/-repo/s1/subagents/agent-a.jsonl"
    run working
    assert_success
}

@test "an agent that was killed is no longer in front, so its file doesn't count" {
    processes "100 1 100 100 $pts 100 5" "200 100 200 100 $pts 100 0"
    agent working s1
    run working
    assert_failure
}

@test "the files of agents that are gone are removed" {
    in_front 0
    agent "done"
    printf 'working\t\n' >"$agents/999"
    working || true
    assert [ -e "$agents/200" ]
    assert [ ! -e "$agents/999" ]
}
