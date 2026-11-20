#!/usr/bin/env bats
# caffeine-menu and caffeine-status: the timer that holds off sleep, and the
# bar block showing it and caffeine-agents' inhibitor.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

cup=$'\U000F0176'
robot=$'\U000F06A9'
empty_cup=$'\U000F06CA'
real_setsid=$(command -v setsid)

setup() {
    # shellcheck disable=SC2119 # the usual tools only
    isolate
    stub elogind-inhibit 'cat "'"$BATS_TEST_TMPDIR"'/inhibitors" 2>/dev/null || true'
    logged pkill setsid
}

teardown() {
    [ -z "${caffeine:-}" ] || kill "$caffeine" 2>/dev/null || true
}

# timer_running <until>: a process named caffeine, as the timer's is, in its own
# process group, recorded as ending then (0 = never).
timer_running() {
    "$real_setsid" bash -c 'exec -a caffeine sleep 30' &
    caffeine=$!
    echo "$caffeine $1" >"$XDG_RUNTIME_DIR/caffeine"
}

# agents_holding: caffeine-agents' inhibitor among elogind's.
agents_holding() {
    echo 'agents   1000 maro 1234 caffeine-agents sleep work in progress in a terminal block' >"$tmp/inhibitors"
}

@test "status: an empty cup while nothing holds off sleep" {
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$empty_cup\"}"
}

@test "status: a full cup with the minutes left, rounded up" {
    timer_running $((EPOCHSECONDS + 241))
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$cup 5m\",\"state\":\"Good\"}"
}

@test "status: a full cup alone for a timer without end" {
    timer_running 0
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$cup\",\"state\":\"Good\"}"
}

@test "status: a timer past its end, or whose process is gone, holds nothing" {
    timer_running $((EPOCHSECONDS - 1))
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$empty_cup\"}"
    echo "999999 0" >"$XDG_RUNTIME_DIR/caffeine"
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$empty_cup\"}"
}

@test "status: a robot while agents work, before the cup when both hold" {
    agents_holding
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$robot\",\"state\":\"Good\"}"
    timer_running 0
    run "$bin/caffeine-status"
    assert_output "{\"text\":\"$robot $cup\",\"state\":\"Good\"}"
}

@test "menu: a time starts a timer that ends then, and refreshes the bar" {
    fuzzel_picks '10 min'
    run "$bin/caffeine-menu"
    assert_success
    read -r pid until <"$XDG_RUNTIME_DIR/caffeine"
    assert [ "$pid" -gt 0 ]
    assert [ $((until - EPOCHSECONDS)) -ge 598 ]
    assert [ $((until - EPOCHSECONDS)) -le 600 ]
    eventually grep -q '^setsid' "$tmp/calls"
    run calls
    assert_line --partial "setsid sh -c elogind-inhibit --what=sleep --who=caffeine"
    assert_output --partial "i3status-rs sh $until"
    assert_line "pkill -RTMIN+9 -x i3status-rs"
}

@test "menu: indefinitely starts a timer without end" {
    fuzzel_picks indefinitely
    run "$bin/caffeine-menu"
    read -r _ until <"$XDG_RUNTIME_DIR/caffeine"
    assert_equal "$until" 0
}

@test "menu: off stops the running timer and starts none" {
    timer_running 0
    fuzzel_picks off
    run "$bin/caffeine-menu"
    assert_success
    run wait "$caffeine"
    assert_equal "$status" 143
    assert [ ! -e "$XDG_RUNTIME_DIR/caffeine" ]
    assert_equal "$(calls)" "pkill -RTMIN+9 -x i3status-rs"
}

@test "menu: a new time replaces the running timer" {
    timer_running 0
    fuzzel_picks '5 min'
    run "$bin/caffeine-menu"
    run wait "$caffeine"
    assert_equal "$status" 143
    read -r pid _ <"$XDG_RUNTIME_DIR/caffeine"
    assert [ "$pid" != "$caffeine" ]
}

@test "menu: while agents work, a first line says so, and picking it changes nothing" {
    agents_holding
    timer_running 0
    fuzzel_picks "$robot agents working: awake until they finish"
    run "$bin/caffeine-menu"
    assert_success
    assert_equal "$(head -2 "$tmp/menu")" "$robot agents working: awake until they finish
off"
    assert_equal "$(calls)" ""
    assert [ -e "$XDG_RUNTIME_DIR/caffeine" ]
}

@test "menu: escape changes nothing" {
    fuzzel_picks ''
    run "$bin/caffeine-menu"
    assert_success
    assert_equal "$(calls)" ""
}
