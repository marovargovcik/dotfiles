#!/usr/bin/env bats
# bt-status against a stand-in BlueZ: busctl answers from a file per device,
# and gdbus monitor reports one change.

# shellcheck source=helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

off=$'\U000F00AF'
on=$'\U000F00B1'

setup() {
    isolate jq cp mv
    mkdir "$tmp/devices"
    # shellcheck disable=SC2016 # expanded by the stub
    stub busctl 'devices='"$tmp"'/devices
case $* in
*"--list tree org.bluez")
    printf "%s\n" / /org /org/bluez /org/bluez/hci0
    for d in "$devices"/*; do [ -e "$d" ] && echo "/org/bluez/hci0/${d##*/}"; done
    ;;
*get-property*) cat "$devices/${5##*/}" ;;
esac'
    # The change: the file of a device in $tmp/change replaces its own.
    # shellcheck disable=SC2016 # expanded by the stub
    stub gdbus 'tmp='"$tmp"'
echo "/org/bluez/hci0: org.freedesktop.DBus.Properties.PropertiesChanged (\"org.bluez.Adapter1\", {\"Discovering\": <true>}, @as [])"
[ -e "$tmp/change" ] || exit 0
cp "$tmp/change" "$tmp/devices/$(cat "$tmp/change.name")"
echo "/org/bluez/hci0/dev_X: org.freedesktop.DBus.Properties.PropertiesChanged (\"org.bluez.Device1\", {'\''Connected'\'': <true>}, @as [])"'
}

# device <name> <connected> <alias> <address> [bluez name]: a device as
# get-property prints its properties, one JSON value per line.
device() {
    {
        printf '{"type":"b","data":%s}\n' "$2"
        printf '{"type":"s","data":"%s"}\n' "$3" "$4" ${5:+"$5"}
    } >"$tmp/devices/$1"
}

@test "nothing connected" {
    device dev_AA false Buds AA:AA Buds
    run "$bin/bt-status"
    assert_output "$off"
}

@test "one device, by its alias without the spaces around it" {
    device dev_AA true ' QCY MeloBuds N20 ' AA:AA 'QCY MeloBuds N20'
    run "$bin/bt-status"
    assert_output "$on QCY MeloBuds N20"
}

@test "a named device before an unnamed one, which counts as one more" {
    device dev_11 true 11-22-33 11:22:33
    device dev_AA true Buds AA:AA Buds
    run "$bin/bt-status"
    assert_output "$on Buds (+1)"
}

@test "an unnamed device alone goes by its address" {
    device dev_11 true 11-22-33 11:22:33
    run "$bin/bt-status"
    assert_output "$on 11:22:33"
}

@test "it prints again when a device connects, and not on other changes" {
    device dev_AA true Buds AA:AA Buds
    mv "$tmp/devices/dev_AA" "$tmp/change"
    echo dev_AA >"$tmp/change.name"
    device dev_AA false Buds AA:AA Buds
    run "$bin/bt-status"
    assert_output "$off
$on Buds"
}
