# shellcheck shell=bash
# Shared by the bin scripts' tests: bats-support and bats-assert, and a PATH of
# stand-in tools, so nothing reaches the real bar, disks or tunnels.

bats_require_minimum_version 1.5.0
bats_load_library bats-support
bats_load_library bats-assert

# shellcheck disable=SC2034 # used by the tests
bin=$(realpath "$BATS_TEST_DIRNAME/../.local/bin")
# shellcheck disable=SC2034
fixtures=$BATS_TEST_DIRNAME/fixtures

# isolate <tool...>: a home and runtime directory of the test's own, and a PATH
# with only the tools named and the test's stubs.
isolate() {
    tmp=$BATS_TEST_TMPDIR
    export HOME=$tmp/home XDG_RUNTIME_DIR=$tmp/run
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$tmp/bin"
    local tool
    for tool in bash env cat grep sed awk tr head tail paste basename dirname realpath rm mkdir chmod sleep touch "$@"; do
        ln -sf "$(command -v "$tool")" "$tmp/bin/$tool"
    done
    PATH=$tmp/bin
}

# stub <tool> [script]: a stand-in for the tool that runs the script, such as `exit 1`.
stub() {
    printf '#!/usr/bin/env bash\n%s\n' "${2:-}" >"$tmp/bin/$1"
    chmod +x "$tmp/bin/$1"
}

# logged <tool...>: stand-ins that only append each call to $tmp/calls.
logged() {
    local tool
    for tool; do
        stub "$tool" "echo $tool \"\$@\" >>\"$tmp/calls\""
    done
}

# calls: the calls the logged stand-ins got, one per line.
calls() { cat "$tmp/calls" 2>/dev/null || true; }

# fuzzel_picks <line...>: a fuzzel that keeps the menu it's shown in
# $tmp/menu and answers each call with the next line given, then nothing (as
# escape does).
fuzzel_picks() {
    printf '%s\n' "$@" >"$tmp/picks"
    # shellcheck disable=SC2016 # expanded by the stub
    stub fuzzel 'cat >"'"$tmp"'/menu"
pick=$(head -1 "'"$tmp"'/picks")
sed -i 1d "'"$tmp"'/picks"
[ -n "$pick" ] && echo "$pick"'
}

# eventually <command...>: retries the command for up to five seconds, for what
# a script leaves running in the background.
eventually() {
    local i
    for ((i = 0; i < 50; i++)); do
        "$@" 2>/dev/null && return 0
        sleep 0.1
    done
    "$@"
}
