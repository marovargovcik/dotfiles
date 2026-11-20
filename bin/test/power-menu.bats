#!/usr/bin/env bats
# power-menu: lock, sleep, restart or power off, with no sudo.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    # shellcheck disable=SC2119 # the usual tools only
    isolate
    logged swaylock loginctl
}

@test "the menu" {
    fuzzel_picks ''
    run "$bin/power-menu"
    assert_equal "$(cat "$tmp/menu")" "lock
sleep
restart
power-off"
    assert_equal "$(calls)" ""
}

@test "each entry's action" {
    for pick in lock sleep restart power-off; do
        fuzzel_picks "$pick"
        "$bin/power-menu"
    done
    assert_equal "$(calls)" "swaylock
loginctl suspend-then-hibernate
loginctl reboot
loginctl poweroff"
}
