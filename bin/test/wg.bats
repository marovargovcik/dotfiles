#!/usr/bin/env bats
# wg-menu and wg-status: the WireGuard tunnels of ~/.config/wireguard.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    isolate stdbuf
    mkdir -p "$HOME/.config/wireguard"
    touch "$HOME/.config/wireguard/home.conf" "$HOME/.config/wireguard/work.conf"
    stub sudo 'exec "$@"'
    stub wg 'echo home'
    logged wg-quick
}

@test "the menu lists every tunnel, marking the connected ones" {
    fuzzel_picks ''
    run "$bin/wg-menu"
    assert_success
    assert_equal "$(cat "$tmp/menu")" "[connected] home
work"
    assert_equal "$(calls)" ""
}

@test "picking a connected tunnel brings it down" {
    fuzzel_picks '[connected] home'
    run "$bin/wg-menu"
    assert_equal "$(calls)" "wg-quick down $HOME/.config/wireguard/home.conf"
}

@test "picking another brings it up" {
    fuzzel_picks work
    run "$bin/wg-menu"
    assert_equal "$(calls)" "wg-quick up $HOME/.config/wireguard/work.conf"
}

@test "with no tunnels, no menu" {
    rm "$HOME"/.config/wireguard/*
    fuzzel_picks work
    run "$bin/wg-menu"
    assert_success
    assert [ ! -e "$tmp/menu" ]
}

# links <state...>: an ip that answers each `ip -o link show type wireguard`
# with the next state's tunnels (- for none), and whose monitor reports a link
# event per state after the first.
links() {
    printf '%s\n' "$@" >"$tmp/links"
    # shellcheck disable=SC2016 # expanded by the stub
    stub ip 'links='"$tmp"'/links
if [ "$1" = monitor ]; then
    for ((i = 1; i < '"$#"'; i++)); do echo "3: wg0: <POINTOPOINT,NOARP,UP>"; done
    exit
fi
n=0
for name in $(head -1 "$links"); do
    [ "$name" = - ] || echo "$((n += 1)): $name: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue"
done
sed -i 1d "$links"'
}

@test "the bar block prints the tunnels up, then again on each change" {
    links - wg0 wg0 "wg0 wg1" -
    run "$bin/wg-status"
    assert_success
    assert_output "VPN off
VPN wg0
VPN wg0 wg1
VPN off"
}
