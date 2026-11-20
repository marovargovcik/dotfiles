# shellcheck shell=bash
# What the caffeine scripts share: the timer's state file, the inhibitor
# caffeine-agents holds, and the bar block showing both.

# Holds the timer's inhibitor's pid and when it ends (0 = never).
state="$XDG_RUNTIME_DIR/caffeine"

# timer: the running timer's pid and when it ends; fails when none runs. The
# cmdline check skips a pid that has since been reused by something else.
timer() {
    local pid until
    read -r pid until 2>/dev/null <"$state" && grep -qs caffeine "/proc/$pid/cmdline" && echo "$pid $until"
}

# agents_awake: whether caffeine-agents holds its inhibitor.
agents_awake() { elogind-inhibit --list --no-legend | grep -q '^agents '; }

# refresh_bar: has i3status-rs redraw the caffeine block.
refresh_bar() { pkill -RTMIN+9 -x i3status-rs; }
